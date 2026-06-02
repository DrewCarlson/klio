//! Low-level CFG construction primitives. The AST → CFG lowering
//! pass (`lower.rs`) drives this builder; tests construct CFGs
//! directly through it. The builder is intentionally dumb: it
//! allocates blocks, registers, and edges; it does not know about
//! the source language.

use crate::ir::{BasicBlock, BlockId, Cfg, Edge, EdgeKind, LabelId, LoopId, Node, Reg, Terminator};
use klio_span::Span;

pub struct CfgBuilder {
    blocks: Vec<BasicBlock>,
    next_reg: u32,
    next_loop: u32,
    next_label: u32,
}

impl CfgBuilder {
    #[must_use]
    pub fn new() -> Self {
        Self {
            blocks: Vec::new(),
            next_reg: 0,
            next_loop: 0,
            next_label: 0,
        }
    }

    /// # Panics
    /// Panics if the block count exceeds `u32::MAX`.
    pub fn new_block(&mut self) -> BlockId {
        let id = BlockId(u32::try_from(self.blocks.len()).expect("block id overflow"));
        self.blocks.push(BasicBlock {
            id,
            nodes: Vec::new(),
            term: Terminator::Unreachable,
            preds: Vec::new(),
            succs: Vec::new(),
        });
        id
    }

    /// # Panics
    /// Panics if the register count exceeds `u32::MAX`.
    pub fn new_reg(&mut self) -> Reg {
        let r = Reg(self.next_reg);
        self.next_reg = self.next_reg.checked_add(1).expect("reg id overflow");
        r
    }

    /// # Panics
    /// Panics if the loop count exceeds `u32::MAX`.
    pub fn new_loop(&mut self) -> LoopId {
        let id = LoopId(self.next_loop);
        self.next_loop = self.next_loop.checked_add(1).expect("loop id overflow");
        id
    }

    /// # Panics
    /// Panics if the label count exceeds `u32::MAX`.
    pub fn new_label(&mut self) -> LabelId {
        let id = LabelId(self.next_label);
        self.next_label = self.next_label.checked_add(1).expect("label id overflow");
        id
    }

    /// Append a node to the given block. Order-sensitive.
    pub fn push(&mut self, blk: BlockId, node: Node) {
        self.blocks[blk.0 as usize].nodes.push(node);
    }

    /// Number of nodes already in `blk`. Useful for callers that
    /// want to remember the position a node is about to be pushed
    /// into — the returned value is the insertion index.
    #[must_use]
    pub fn current_node_count(&self, blk: BlockId) -> Option<usize> {
        self.blocks.get(blk.0 as usize).map(|b| b.nodes.len())
    }

    /// Set the terminator for a block and wire up the edges to the
    /// referenced successors. Replaces any prior terminator on
    /// `blk` and any preds/succs implied by it.
    pub fn set_terminator(&mut self, blk: BlockId, term: Terminator) {
        self.unwire_succs(blk);
        let succs: Vec<Edge> = match &term {
            Terminator::Goto(t) => vec![Edge {
                block: *t,
                kind: EdgeKind::Normal,
            }],
            Terminator::Branch {
                then_blk, else_blk, ..
            } => vec![
                Edge {
                    block: *then_blk,
                    kind: EdgeKind::True,
                },
                Edge {
                    block: *else_blk,
                    kind: EdgeKind::False,
                },
            ],
            Terminator::Switch { arms, default, .. } => {
                let mut v: Vec<Edge> = arms
                    .iter()
                    .map(|a| Edge {
                        block: a.target,
                        kind: EdgeKind::Normal,
                    })
                    .collect();
                v.push(Edge {
                    block: *default,
                    kind: EdgeKind::Normal,
                });
                v
            }
            Terminator::Throw(_) | Terminator::Return(_) | Terminator::Unreachable => Vec::new(),
        };
        self.blocks[blk.0 as usize].term = term;
        for edge in &succs {
            self.blocks[edge.block.0 as usize].preds.push(Edge {
                block: blk,
                kind: edge.kind.clone(),
            });
        }
        self.blocks[blk.0 as usize].succs = succs;
    }

    /// Add an additional out-edge of an arbitrary kind from `from` to
    /// `to`. Used for exception edges and finally entry/exit, which
    /// are not implied by the terminator shape.
    pub fn add_edge(&mut self, from: BlockId, to: BlockId, kind: EdgeKind) {
        self.blocks[from.0 as usize].succs.push(Edge {
            block: to,
            kind: kind.clone(),
        });
        self.blocks[to.0 as usize]
            .preds
            .push(Edge { block: from, kind });
    }

    /// Detach any preds that point to `blk`'s prior terminator-implied
    /// successors so we can replace them cleanly.
    fn unwire_succs(&mut self, blk: BlockId) {
        let prior: Vec<Edge> = std::mem::take(&mut self.blocks[blk.0 as usize].succs);
        for edge in prior {
            let dst = &mut self.blocks[edge.block.0 as usize].preds;
            if let Some(idx) = dst
                .iter()
                .position(|e| e.block == blk && e.kind == edge.kind)
            {
                dst.swap_remove(idx);
            }
        }
    }

    #[must_use]
    pub fn finish(self, entry: BlockId, exits: Vec<BlockId>, source: Span) -> Cfg {
        Cfg {
            blocks: self.blocks,
            entry,
            exits,
            source,
            next_reg: self.next_reg,
        }
    }
}

impl Default for CfgBuilder {
    fn default() -> Self {
        Self::new()
    }
}
