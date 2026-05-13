//! Reachability analysis (spec §12.1.5).
//!
//! A block is reachable iff there is a path from the CFG's entry to
//! it through edges that the dataflow regards as live. An edge is
//! dead when its source block ends in a divergent terminator
//! (`Throw`, `Return`, `Unreachable`) or when an `Unreachable`
//! node is encountered before the terminator (typical for code
//! after a `Nothing`-typed call).
//!
//! Phase 6 will reroute `W0002 unreachable code` and similar
//! diagnostics through this pass.

use crate::ir::{BlockId, Cfg, Node, Terminator};
use std::collections::BTreeSet;

#[derive(Debug, Clone)]
pub struct Reachability {
    reachable: Vec<bool>,
}

impl Reachability {
    pub fn is_reachable(&self, b: BlockId) -> bool {
        self.reachable.get(b.0 as usize).copied().unwrap_or(false)
    }

    pub fn unreachable_blocks(&self) -> Vec<BlockId> {
        self.reachable
            .iter()
            .enumerate()
            .filter_map(|(i, r)| if *r { None } else { Some(BlockId(i as u32)) })
            .collect()
    }
}

pub fn analyse(cfg: &Cfg) -> Reachability {
    let mut reachable = vec![false; cfg.blocks.len()];
    let mut stack: Vec<BlockId> = vec![cfg.entry];
    let mut visited: BTreeSet<BlockId> = BTreeSet::new();

    while let Some(b) = stack.pop() {
        if !visited.insert(b) {
            continue;
        }
        reachable[b.0 as usize] = true;
        let block = cfg.block(b);
        // Block-internal divergence: any explicit Unreachable node
        // before the terminator kills the rest of the block but we
        // still mark the block reachable (entry survived).
        if block.nodes.iter().any(|n| matches!(n, Node::Unreachable)) {
            continue;
        }
        // Successors propagate only when the terminator is
        // non-divergent. Throw/Return/Unreachable do not propagate
        // by their nature, even though the IR records preds for
        // exception edges separately.
        match &block.term {
            Terminator::Throw(_) | Terminator::Return(_) | Terminator::Unreachable => {}
            _ => {
                for e in &block.succs {
                    stack.push(e.block);
                }
            }
        }
    }
    Reachability { reachable }
}
