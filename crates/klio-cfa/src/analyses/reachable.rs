//! Reachability analysis (spec §12.1.5).
//!
//! A block is reachable iff there is a path from the CFG's entry to
//! it through edges that the dataflow regards as live. An edge is
//! dead when its source block ends in a divergent terminator
//! (`Throw`, `Return`, `Unreachable`) or when an `Unreachable`
//! node is encountered before the terminator (typical for code
//! after a `Nothing`-typed call).
//!
//! The `_with_types` variant consults a span-keyed type map so an
//! `Eval` of a `Nothing`-returning call (`error("…")`, `TODO()`)
//! prunes its block's successors the same way an explicit
//! `Throw` would. The typechecker passes its `types` map in.

use crate::ir::{BlockId, Cfg, Node, Terminator};
use klio_types::Type;
use std::collections::{BTreeSet, HashMap};
use std::hash::BuildHasher;

#[derive(Debug, Clone)]
pub struct Reachability {
    reachable: Vec<bool>,
}

impl Reachability {
    #[must_use]
    pub fn is_reachable(&self, b: BlockId) -> bool {
        self.reachable.get(b.0 as usize).copied().unwrap_or(false)
    }

    #[must_use]
    // block count fits in u32
    #[allow(clippy::cast_possible_truncation)]
    pub fn unreachable_blocks(&self) -> Vec<BlockId> {
        self.reachable
            .iter()
            .enumerate()
            .filter_map(|(i, r)| if *r { None } else { Some(BlockId(i as u32)) })
            .collect()
    }
}

#[must_use]
pub fn analyse(cfg: &Cfg) -> Reachability {
    analyse_with_types::<std::collections::hash_map::RandomState>(cfg, None)
}

/// Same as `analyse` but consults `type_map` (typechecker-supplied
/// span→Type results) so an `Eval` of a `Nothing`-typed expression
/// is treated like an in-block `Unreachable` marker: control does
/// not propagate past it.
#[must_use]
pub fn analyse_with_types<S: BuildHasher>(
    cfg: &Cfg,
    type_map: Option<&HashMap<(u32, u32), Type, S>>,
) -> Reachability {
    let mut reachable = vec![false; cfg.blocks.len()];
    let mut stack: Vec<BlockId> = vec![cfg.entry];
    let mut visited: BTreeSet<BlockId> = BTreeSet::new();

    while let Some(b) = stack.pop() {
        if !visited.insert(b) {
            continue;
        }
        reachable[b.0 as usize] = true;
        let block = cfg.block(b);
        let block_diverges = block.nodes.iter().any(|n| match n {
            Node::Unreachable => true,
            Node::Eval { expr, .. } => match type_map {
                Some(tm) => matches!(
                    tm.get(&(expr.span.start, expr.span.end)),
                    Some(Type::Nothing)
                ),
                None => matches!(expr.ty, Type::Nothing),
            },
            _ => false,
        });
        if block_diverges {
            continue;
        }
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
