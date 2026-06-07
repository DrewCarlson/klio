//! Control-flow graph IR for analyses on Kotlin functions.
//!
//! This module hosts the IR (`ir`), low-level construction primitives
//! (`builder`), and a snapshot-printable form (`print`). The AST →
//! CFG lowering (`lower`) and the dataflow framework (`dataflow`)
//! build on top of this without touching the types here.

pub const analyses = @import("analyses/mod.zig");
pub const builder = @import("builder.zig");
pub const dataflow = @import("dataflow.zig");
pub const ir = @import("ir.zig");
pub const lower = @import("lower.zig");
pub const print = @import("print.zig");

pub const CfgBuilder = builder.CfgBuilder;

pub const BasicBlock = ir.BasicBlock;
pub const BlockId = ir.BlockId;
pub const Cfg = ir.Cfg;
pub const Edge = ir.Edge;
pub const EdgeKind = ir.EdgeKind;
pub const ExprRef = ir.ExprRef;
pub const FieldId = ir.FieldId;
pub const LabelId = ir.LabelId;
pub const LoopId = ir.LoopId;
pub const Node = ir.Node;
pub const Pattern = ir.Pattern;
pub const Place = ir.Place;
pub const Reg = ir.Reg;
pub const SwitchArm = ir.SwitchArm;
pub const Symbol = ir.Symbol;
pub const Terminator = ir.Terminator;

pub const printCfg = print.printCfg;

test {
    const testing = @import("std").testing;
    testing.refAllDecls(@This());
    inline for (.{ analyses, builder, dataflow, ir, lower, print }) |m| {
        testing.refAllDecls(m);
    }
    inline for (.{ analyses.contracts, analyses.finally, analyses.reachable, analyses.smartcast, analyses.via }) |m| {
        testing.refAllDecls(m);
    }
}
