//! Smart-cast and nullability dataflow (spec §8.11.2, §12.2.4).
//!
//! The lattice is `Map<Place, SmartCastFact>` where each fact bundles
//! a refined type (intersected as paths join) and a nullability axis
//! (definitely non-null / definitely null / unknown). Transfer
//! functions consume `AssumeIs`, `AssumeNull`, `Assign`, and
//! `KillDataFlow`. The mapping from register-bearing nodes back to
//! `Place` comes from the lowering's `reg_to_place` table.

use crate::dataflow::{ForwardTransfer, Lattice, MapLattice, solve_forward};
use crate::ir::{Cfg, Node, Place, Reg};
use klio_types::Type;
use std::collections::HashMap;

/// A single fact about a `Place` at a program point.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SmartCastFact {
    /// The type the place has been narrowed to along this path. `None`
    /// means "no narrowing" — fall back to the declared type.
    pub narrowed: Option<Type>,
    /// Negative `is` refinements: types the place is known *not* to
    /// be along this path. Used for exhaustive-`when` propagation.
    pub not_types: Vec<Type>,
    /// Nullability axis.
    pub null: Nullability,
}

#[derive(Debug, Clone, PartialEq, Eq, Copy)]
pub enum Nullability {
    Unknown,
    /// `x != null` is known to hold.
    NonNull,
    /// `x == null` is known to hold.
    DefinitelyNull,
}

impl SmartCastFact {
    pub fn unknown() -> Self {
        Self { narrowed: None, not_types: Vec::new(), null: Nullability::Unknown }
    }

    /// Compose `self` with an `is T` narrowing. Intersection-on-rhs
    /// when both are non-trivial; otherwise the more specific one
    /// wins by direct replacement (Type::intersect normalises).
    pub fn assume_is(&mut self, ty: Type) {
        self.narrowed = Some(match self.narrowed.take() {
            Some(prev) => intersect(prev, ty),
            None => ty,
        });
    }

    pub fn assume_not_is(&mut self, ty: Type) {
        if !self.not_types.iter().any(|t| t == &ty) {
            self.not_types.push(ty);
        }
    }

    pub fn assume_null(&mut self) {
        self.null = match self.null {
            Nullability::Unknown | Nullability::DefinitelyNull => Nullability::DefinitelyNull,
            Nullability::NonNull => Nullability::Unknown,
        };
    }

    pub fn assume_non_null(&mut self) {
        self.null = match self.null {
            Nullability::Unknown | Nullability::NonNull => Nullability::NonNull,
            Nullability::DefinitelyNull => Nullability::Unknown,
        };
    }

    pub fn reset(&mut self) {
        *self = Self::unknown();
    }
}

impl Lattice for SmartCastFact {
    fn bottom() -> Self {
        Self::unknown()
    }
    fn join(&mut self, other: &Self) -> bool {
        let mut changed = false;
        let new_narrow = match (self.narrowed.clone(), other.narrowed.clone()) {
            (Some(a), Some(b)) => {
                let merged = union_of(a, b);
                Some(merged)
            }
            (Some(_), None) | (None, Some(_)) => None,
            (None, None) => None,
        };
        if new_narrow != self.narrowed {
            self.narrowed = new_narrow;
            changed = true;
        }
        // Negative refinements intersect: only those known on *both*
        // sides survive.
        let new_not: Vec<Type> = self
            .not_types
            .iter()
            .filter(|t| other.not_types.iter().any(|o| o == *t))
            .cloned()
            .collect();
        if new_not != self.not_types {
            self.not_types = new_not;
            changed = true;
        }
        let new_null = match (self.null, other.null) {
            (a, b) if a == b => a,
            _ => Nullability::Unknown,
        };
        if new_null != self.null {
            self.null = new_null;
            changed = true;
        }
        changed
    }
}

/// Intersection of two types, materialised as `Type::Intersection`
/// when both sides are non-trivial. Mirrors the typechecker's
/// existing intersection construction.
fn intersect(a: Type, b: Type) -> Type {
    if a == b {
        return a;
    }
    Type::Intersection(vec![a, b])
}

/// Union for join points. With only `Type::Intersection` available
/// for refinement and no explicit union variant, we conservatively
/// drop the narrowing when the two branches disagree — same as the
/// current typechecker behavior.
fn union_of(a: Type, b: Type) -> Type {
    if a == b {
        a
    } else {
        Type::Any
    }
}

pub type SmartCastLattice = MapLattice<Place, SmartCastFact>;

pub struct SmartCastTransfer<'a> {
    pub reg_to_place: &'a HashMap<Reg, Place>,
}

impl<'a> ForwardTransfer<SmartCastLattice> for SmartCastTransfer<'a> {
    fn transfer_node(&mut self, node: &Node, state: &mut SmartCastLattice) {
        match node {
            Node::AssumeIs { reg, ty, polarity, .. } => {
                if let Some(place) = self.reg_to_place.get(reg) {
                    let mut fact = state.map.get(place).cloned().unwrap_or_else(SmartCastFact::unknown);
                    if *polarity {
                        fact.assume_is(ty.clone());
                    } else {
                        fact.assume_not_is(ty.clone());
                    }
                    state.put(place.clone(), fact);
                }
            }
            Node::AssumeNull { reg, eq_null, .. } => {
                if let Some(place) = self.reg_to_place.get(reg) {
                    let mut fact = state.map.get(place).cloned().unwrap_or_else(SmartCastFact::unknown);
                    if *eq_null {
                        fact.assume_null();
                    } else {
                        fact.assume_non_null();
                    }
                    state.put(place.clone(), fact);
                }
            }
            Node::Assign { lhs, .. } => {
                let mut fact = SmartCastFact::unknown();
                fact.reset();
                state.put(lhs.clone(), fact);
            }
            Node::KillDataFlow { place } => {
                let mut fact = SmartCastFact::unknown();
                fact.reset();
                state.put(place.clone(), fact);
            }
            _ => {}
        }
    }
}

/// Run the smart-cast analysis to fixpoint. Returns per-block in-
/// states; the caller queries facts at the entry of the block
/// containing a given AST span.
pub fn solve(cfg: &Cfg, reg_to_place: &HashMap<Reg, Place>) -> Vec<SmartCastLattice> {
    solve_forward(
        cfg,
        SmartCastLattice::new(),
        SmartCastTransfer { reg_to_place },
    )
}

/// Reproduce the per-node in-state walk inside a block. Mirrors
/// `analyses::via::states_within_block` for ad-hoc lookups.
pub fn states_within_block(
    cfg: &Cfg,
    block: crate::ir::BlockId,
    entry: SmartCastLattice,
    reg_to_place: &HashMap<Reg, Place>,
) -> Vec<SmartCastLattice> {
    let mut out: Vec<SmartCastLattice> = Vec::with_capacity(cfg.block(block).nodes.len() + 1);
    let mut s = entry;
    out.push(s.clone());
    let mut t = SmartCastTransfer { reg_to_place };
    for node in &cfg.block(block).nodes {
        t.transfer_node(node, &mut s);
        out.push(s.clone());
    }
    out
}
