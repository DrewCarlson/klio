//! Variable initialisation analysis (spec §12.2.3).
//!
//! Forward pass over the CFG with a `Map<Place, Flat<AssignState>>`
//! lattice. `DeclLocal` seeds `Unassigned`; `Assign` sets `Assigned`.
//! A read of a place whose state is not `Assigned` (i.e. `Unassigned`
//! or `Top` — "may be unassigned along some path") is a definite-
//! assignment violation. A future integration step reroutes T0020
//! onto this analysis; for now we expose the per-place facts and a
//! helper that reports violations as a list of spans.

use crate::dataflow::{Flat, ForwardTransfer, Lattice, MapLattice, solve_forward};
use crate::ir::{BlockId, Cfg, Node, Place};
use klio_span::Span;
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AssignState {
    /// Declared but no `Assign` has been seen on this path.
    Unassigned,
    /// Definitely assigned on this path.
    Assigned,
}

pub type ViaLattice = MapLattice<Place, Flat<AssignState>>;

#[derive(Default)]
pub struct ViaTransfer;

impl ForwardTransfer<ViaLattice> for ViaTransfer {
    fn transfer_node(&mut self, node: &Node, state: &mut ViaLattice) {
        match node {
            Node::DeclLocal { place, .. } => {
                let p = Place::Local(crate::ir::Symbol(place.0.clone()));
                state.put(p, Flat::Value(AssignState::Unassigned));
            }
            Node::Assign { lhs, .. } => {
                state.put(lhs.clone(), Flat::Value(AssignState::Assigned));
            }
            _ => {}
        }
    }
}

#[derive(Debug, Clone)]
pub struct UnassignedRead {
    pub place: Place,
    pub span: Span,
}

/// Per-block in-state at fixpoint.
pub type ViaBlockStates = Vec<ViaLattice>;

pub fn solve_via(cfg: &Cfg) -> ViaBlockStates {
    let mut entry: ViaLattice = MapLattice::new();
    // Function parameters land as "assigned" before we enter the
    // function body; the lowering doesn't currently emit `DeclLocal`
    // for them, which means absent ⇒ "no fact" ⇒ not flagged.
    let _ = &mut entry;
    solve_forward(cfg, entry, ViaTransfer)
}

/// Returns the in-state at every node in `block` by re-running the
/// transfer from the block's start. Useful for a downstream
/// "check at this AST span" query without a full per-node array.
pub fn states_within_block(cfg: &Cfg, block: BlockId, entry: ViaLattice) -> Vec<ViaLattice> {
    let mut out: Vec<ViaLattice> = Vec::with_capacity(cfg.block(block).nodes.len() + 1);
    let mut s = entry;
    out.push(s.clone());
    let mut t = ViaTransfer;
    for node in &cfg.block(block).nodes {
        t.transfer_node(node, &mut s);
        out.push(s.clone());
    }
    out
}

/// Read of a place is "live" when the place is named on the right of
/// an `Eval` whose AST shape would touch it. The IR does not record
/// reads directly — those live in `ExprRef.span`. This helper
/// therefore returns the per-block fact stream so the typechecker
/// can query "is this place assigned at this span?" by
/// indexing the state map with the place at the eval's preceding
/// program point.
pub fn place_state_at_block_entry(
    states: &ViaBlockStates,
    block: BlockId,
    place: &Place,
) -> Flat<AssignState> {
    states[block.0 as usize].get(place)
}

/// Convenience aggregator: collect places that join to `Top`
/// (i.e. "assigned on some paths, not all") at any block entry.
/// These are candidates for a "variable might be uninitialised"
/// diagnostic.
pub fn maybe_unassigned_places(states: &ViaBlockStates) -> BTreeMap<Place, Vec<BlockId>> {
    let mut out: BTreeMap<Place, Vec<BlockId>> = BTreeMap::new();
    for (i, st) in states.iter().enumerate() {
        for (place, flat) in &st.map {
            if matches!(flat, Flat::Top | Flat::Value(AssignState::Unassigned)) {
                out.entry(place.clone()).or_default().push(BlockId(i as u32));
            }
        }
    }
    out
}

impl Lattice for AssignState {
    fn bottom() -> Self {
        AssignState::Unassigned
    }
    fn join(&mut self, other: &Self) -> bool {
        if self != other {
            *self = AssignState::Unassigned;
            true
        } else {
            false
        }
    }
}
