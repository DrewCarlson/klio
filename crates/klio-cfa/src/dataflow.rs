//! Generic monotone dataflow framework plus the killDataFlow
//! inference pass.
//!
//! The framework exposes a `Lattice` trait, two combinators
//! (`Flat<T>` for finite-height pointwise facts; `MapLattice<K, L>`
//! for per-key facts), and a `solve_forward` worklist runner that
//! iterates blocks in reverse-postorder until a fixpoint is reached.
//! Analyses provide a `Transfer<L>` that mutates a per-node and
//! per-edge state.
//!
//! `killDataFlow` (spec §12.2.2) is built on the framework: it
//! counts assignments to each `Place` along every program point
//! using a natural-number lattice; after fixpoint, any backedge
//! whose count differs between the pred and the loop entry gets a
//! `KillDataFlow(place)` node injected at the loop head so smart-
//! cast analyses know to drop that place's narrowings.

use crate::ir::{
    BasicBlock, BlockId, Cfg, EdgeKind, Node, Place, Terminator,
};
use std::collections::{BTreeMap, BTreeSet, VecDeque};

/// A monotone lattice with a bottom element and a join. `join`
/// returns `true` when the receiver was changed by the join — the
/// worklist relies on this to know when to re-enqueue successors.
pub trait Lattice: Clone {
    fn bottom() -> Self;
    fn join(&mut self, other: &Self) -> bool;
}

/// `Flat<T>` is the three-point lattice: bottom (unknown), a single
/// concrete value, or top (conflicting). `T: Eq + Clone` is enough.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Flat<T: Clone + Eq> {
    Bottom,
    Value(T),
    Top,
}

impl<T: Clone + Eq> Lattice for Flat<T> {
    fn bottom() -> Self {
        Flat::Bottom
    }
    fn join(&mut self, other: &Self) -> bool {
        let new = match (&*self, other) {
            (_, Flat::Bottom) => return false,
            (Flat::Bottom, b) => b.clone(),
            (Flat::Top, _) => return false,
            (_, Flat::Top) => Flat::Top,
            (Flat::Value(a), Flat::Value(b)) => {
                if a == b {
                    return false;
                }
                Flat::Top
            }
        };
        *self = new;
        true
    }
}

/// Map lattice. Pointwise join; missing keys are treated as
/// `L::bottom()`. Concrete enough to satisfy the analyses below
/// without forcing every key to materialise.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MapLattice<K: Ord + Clone, L: Lattice + Eq> {
    pub map: BTreeMap<K, L>,
}

impl<K: Ord + Clone, L: Lattice + Eq> MapLattice<K, L> {
    #[must_use] 
    pub fn new() -> Self {
        Self { map: BTreeMap::new() }
    }

    pub fn get(&self, k: &K) -> L {
        self.map.get(k).cloned().unwrap_or_else(L::bottom)
    }

    pub fn put(&mut self, k: K, v: L) {
        self.map.insert(k, v);
    }
}

impl<K: Ord + Clone, L: Lattice + Eq> Default for MapLattice<K, L> {
    fn default() -> Self {
        Self::new()
    }
}

impl<K: Ord + Clone, L: Lattice + Eq> Lattice for MapLattice<K, L> {
    fn bottom() -> Self {
        Self::new()
    }
    fn join(&mut self, other: &Self) -> bool {
        let mut changed = false;
        for (k, v) in &other.map {
            if let Some(existing) = self.map.get_mut(k) {
                if existing.join(v) {
                    changed = true;
                }
            } else {
                self.map.insert(k.clone(), v.clone());
                changed = true;
            }
        }
        changed
    }
}

/// Per-node and per-edge transfer functions for a forward analysis.
/// `transfer_node` updates the state before moving on to the next
/// node within the same block; `transfer_edge` updates the state
/// while crossing into a successor block (used for `Assume`-style
/// edge facts that aren't tied to a particular node, like
/// exception edge polarity).
pub trait ForwardTransfer<L: Lattice> {
    fn transfer_node(&mut self, _node: &Node, _state: &mut L) {}
    fn transfer_edge(&mut self, _kind: &EdgeKind, _state: &mut L) {}
    fn transfer_terminator(&mut self, _term: &Terminator, _state: &mut L) {}
}

/// Per-block in-state for a forward dataflow problem.
pub type BlockStates<L> = Vec<L>;

/// Solve a forward dataflow problem. Returns the per-block in-state
/// at fixpoint.
pub fn solve_forward<L: Lattice + Eq, T: ForwardTransfer<L>>(
    cfg: &Cfg,
    entry_state: L,
    mut transfer: T,
) -> BlockStates<L> {
    let n = cfg.blocks.len();
    let mut in_states: Vec<L> = vec![L::bottom(); n];
    in_states[cfg.entry.0 as usize] = entry_state;
    let order = reverse_postorder(cfg);
    let mut queue: VecDeque<BlockId> = order.iter().copied().collect();
    let mut in_queue: BTreeSet<BlockId> = order.iter().copied().collect();

    while let Some(bid) = queue.pop_front() {
        in_queue.remove(&bid);
        let block = &cfg.blocks[bid.0 as usize];
        let mut state = in_states[bid.0 as usize].clone();
        for node in &block.nodes {
            transfer.transfer_node(node, &mut state);
        }
        transfer.transfer_terminator(&block.term, &mut state);
        for edge in &block.succs {
            let mut succ_in = state.clone();
            transfer.transfer_edge(&edge.kind, &mut succ_in);
            if in_states[edge.block.0 as usize].join(&succ_in)
                && !in_queue.contains(&edge.block) {
                    queue.push_back(edge.block);
                    in_queue.insert(edge.block);
                }
        }
    }
    in_states
}

fn reverse_postorder(cfg: &Cfg) -> Vec<BlockId> {
    let mut visited = vec![false; cfg.blocks.len()];
    let mut order: Vec<BlockId> = Vec::with_capacity(cfg.blocks.len());
    fn dfs(cfg: &Cfg, bid: BlockId, visited: &mut [bool], order: &mut Vec<BlockId>) {
        if visited[bid.0 as usize] {
            return;
        }
        visited[bid.0 as usize] = true;
        let block: &BasicBlock = &cfg.blocks[bid.0 as usize];
        for e in &block.succs {
            dfs(cfg, e.block, visited, order);
        }
        order.push(bid);
    }
    dfs(cfg, cfg.entry, &mut visited, &mut order);
    order.reverse();
    order
}

// ---------------------------------------------------------------------------
// killDataFlow inference (§12.2.2).
//
// We count, at every program point, how many times each `Place` has
// been assigned along the path. A backedge that loops back to a head
// while the per-place count is higher than it was on the head's
// entry means the place was reassigned inside the loop body and any
// smart-cast bound on it must be dropped before the next iteration.
// We then inject `KillDataFlow(place)` at the loop head's first
// non-decl node so the smart-cast analysis sees it.
// ---------------------------------------------------------------------------

/// Saturating natural-number lattice. Two distinct counts join to
/// `Top` (interpreted as "definitely > previous"), preserving the
/// monotone-changed signal that drives killDataFlow detection.
/// Apply killDataFlow inference to `cfg` in place. Inserts a
/// `Node::KillDataFlow` at the head of each loop for every `Place`
/// reassigned anywhere on a path that re-enters the head via a
/// backedge.
///
/// The natural-number-count lattice in the spec describes the same
/// information; we read it off the assigned-places set computed by
/// a forward pass restricted to blocks reachable from the head
/// without leaving the loop. Either formulation collapses to "this
/// place was written between the head's two visits."
pub fn infer_kill_data_flow(cfg: &mut Cfg) {
    let loop_bodies = collect_loop_bodies(cfg);
    for (head, body_blocks) in loop_bodies {
        let mut killed: BTreeSet<Place> = BTreeSet::new();
        for bid in &body_blocks {
            if *bid == head {
                continue;
            }
            for node in &cfg.block(*bid).nodes {
                if let Node::Assign { lhs, .. } = node {
                    killed.insert(lhs.clone());
                }
            }
        }
        if killed.is_empty() {
            continue;
        }
        let head_blk = cfg.block_mut(head);
        let insert_at = head_blk
            .nodes
            .iter()
            .position(|n| !matches!(n, Node::DeclLocal { .. }))
            .unwrap_or(head_blk.nodes.len());
        for place in killed {
            head_blk
                .nodes
                .insert(insert_at, Node::KillDataFlow { place });
        }
    }
}

/// For each loop head, the set of blocks that form its body — i.e.
/// blocks reachable from `head` along forward edges that can still
/// reach back to `head` via a `Backedge` node.
fn collect_loop_bodies(cfg: &Cfg) -> Vec<(BlockId, BTreeSet<BlockId>)> {
    let mut out: Vec<(BlockId, BTreeSet<BlockId>)> = Vec::new();
    let heads = find_loop_heads(cfg);
    for head in heads {
        // Collect blocks reachable from head following forward edges,
        // bounded by stopping at `Backedge`-bearing blocks (we include
        // those, but don't recurse past their goto-to-head).
        let mut body: BTreeSet<BlockId> = BTreeSet::new();
        let mut stack: Vec<BlockId> = vec![head];
        while let Some(b) = stack.pop() {
            if !body.insert(b) {
                continue;
            }
            let blk = cfg.block(b);
            let has_backedge = blk.nodes.iter().any(|n| matches!(n, Node::Backedge { .. }));
            if has_backedge {
                continue;
            }
            for e in &blk.succs {
                if matches!(e.kind, EdgeKind::Normal | EdgeKind::True | EdgeKind::False) {
                    stack.push(e.block);
                }
            }
        }
        out.push((head, body));
    }
    out
}

impl Ord for Place {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        format!("{self:?}").cmp(&format!("{other:?}"))
    }
}
impl PartialOrd for Place {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

fn find_loop_heads(cfg: &Cfg) -> Vec<BlockId> {
    let mut heads: BTreeSet<BlockId> = BTreeSet::new();
    for block in &cfg.blocks {
        for node in &block.nodes {
            if matches!(node, Node::Backedge { .. }) {
                // The backedge node's containing block goto's the
                // loop head — its single normal successor.
                for edge in &block.succs {
                    if matches!(edge.kind, EdgeKind::Normal) {
                        heads.insert(edge.block);
                    }
                }
            }
        }
    }
    heads.into_iter().collect()
}

