//! `finally`-divergence pruning (spec §12.1.1 / §12.1.5).
//!
//! When a `finally` block always diverges (`return`, `throw`, infinite
//! loop), the `try` it wraps cannot reach its normal continuation —
//! every path out of the `try` is replaced by the `finally`'s
//! divergent terminator. The CFG records this by placing a copy of
//! the finally body on each exit path; the analysis here detects the
//! divergent-finally case and prunes the normal-exit edge from the
//! finally copy to the join, leaving only the divergent terminators
//! in place.

use crate::analyses::reachable;
use crate::ir::{BlockId, Cfg, EdgeKind, Terminator};

// block count fits in u32
#[allow(clippy::cast_possible_truncation)]
pub fn prune_divergent_finally(cfg: &mut Cfg) -> usize {
    let mut pruned = 0usize;
    let reach = reachable::analyse(cfg);
    let n = cfg.blocks.len();
    for i in 0..n {
        let bid = BlockId(i as u32);
        if !reach.is_reachable(bid) {
            continue;
        }
        // A FinallyExit edge whose source's terminator is divergent
        // is unreachable and should be detached from the join.
        let to_prune: Vec<usize> = cfg
            .block(bid)
            .succs
            .iter()
            .enumerate()
            .filter(|(_, e)| {
                if !matches!(e.kind, EdgeKind::FinallyExit) {
                    return false;
                }
                let blk = cfg.block(bid);
                matches!(
                    blk.term,
                    Terminator::Throw(_) | Terminator::Return(_) | Terminator::Unreachable
                )
            })
            .map(|(i, _)| i)
            .collect();
        for idx in to_prune.into_iter().rev() {
            let edge = cfg.block_mut(bid).succs.remove(idx);
            let dst_preds = &mut cfg.block_mut(edge.block).preds;
            if let Some(p_idx) = dst_preds
                .iter()
                .position(|p| p.block == bid && p.kind == edge.kind)
            {
                dst_preds.swap_remove(p_idx);
            }
            pruned += 1;
        }
    }
    pruned
}
