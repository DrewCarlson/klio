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
    /// User-class narrowing recorded alongside `narrowed` when the
    /// runtime type is a non-builtin class. The typechecker uses this
    /// to recover the class-name path it previously kept in its
    /// `narrowing_class` map.
    pub narrowed_class: Option<String>,
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
    #[must_use] 
    pub fn unknown() -> Self {
        Self {
            narrowed: None,
            narrowed_class: None,
            not_types: Vec::new(),
            null: Nullability::Unknown,
        }
    }

    /// Compose `self` with an `is T` narrowing. Intersection-on-rhs
    /// when both are non-trivial; otherwise the more specific one
    /// wins by direct replacement (`Type::intersect` normalises). The
    /// optional `class_name` is recorded alongside for user-class
    /// narrowings whose Type is `Unresolved`.
    pub fn assume_is(&mut self, ty: Type, class_name: Option<String>) {
        self.narrowed = Some(match self.narrowed.take() {
            Some(prev) => intersect(prev, ty),
            None => ty,
        });
        if let Some(cn) = class_name {
            self.narrowed_class = Some(cn);
        }
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
        // Class narrowing: drops to None unless both sides agree.
        let new_class = match (&self.narrowed_class, &other.narrowed_class) {
            (Some(a), Some(b)) if a == b => Some(a.clone()),
            _ => None,
        };
        if new_class != self.narrowed_class {
            self.narrowed_class = new_class;
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

/// Intersect two smart-cast facts: the narrowed type is the GLB
/// of both sides (with `None` treated as "no narrowing" so the
/// other side dominates); class-name agreement survives; the
/// nullability axis is the stronger of the two.
fn intersect_facts(a: &SmartCastFact, b: &SmartCastFact) -> SmartCastFact {
    let narrowed = match (a.narrowed.clone(), b.narrowed.clone()) {
        (Some(x), Some(y)) => Some(intersect(x, y)),
        (Some(x), None) => Some(x),
        (None, Some(y)) => Some(y),
        (None, None) => None,
    };
    let narrowed_class = match (&a.narrowed_class, &b.narrowed_class) {
        (Some(x), Some(y)) if x == y => Some(x.clone()),
        (Some(x), None) | (None, Some(x)) => Some(x.clone()),
        _ => None,
    };
    let null = match (a.null, b.null) {
        (Nullability::NonNull, _) | (_, Nullability::NonNull) => Nullability::NonNull,
        (Nullability::DefinitelyNull, _) | (_, Nullability::DefinitelyNull) => {
            Nullability::DefinitelyNull
        }
        _ => Nullability::Unknown,
    };
    let mut not_types: Vec<Type> = a.not_types.clone();
    for t in &b.not_types {
        if !not_types.iter().any(|x| x == t) {
            not_types.push(t.clone());
        }
    }
    SmartCastFact { narrowed, narrowed_class, not_types, null }
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
    /// Declared types per place, supplied by the typechecker before
    /// the analysis runs. Used by `AssumeRefEq` to seed each side
    /// with its declaration when no prior narrowing has refined it.
    pub declared_types: Option<&'a HashMap<Place, Type>>,
}

impl SmartCastTransfer<'_> {
    fn fact_or_declared(&self, place: &Place, state: &SmartCastLattice) -> SmartCastFact {
        let mut fact = state
            .map
            .get(place)
            .cloned()
            .unwrap_or_else(SmartCastFact::unknown);
        if fact.narrowed.is_none()
            && let Some(decl_map) = self.declared_types
                && let Some(t) = decl_map.get(place) {
                    fact.narrowed = Some(t.clone());
                    // Nullable declared types get no automatic
                    // nullability axis — the explicit AssumeNull
                    // nodes carry that signal.
                }
        fact
    }
}

impl ForwardTransfer<SmartCastLattice> for SmartCastTransfer<'_> {
    fn transfer_node(&mut self, node: &Node, state: &mut SmartCastLattice) {
        match node {
            Node::AssumeIs { reg, ty, class_name, polarity, .. } => {
                if let Some(place) = self.reg_to_place.get(reg) {
                    let mut fact = state.map.get(place).cloned().unwrap_or_else(SmartCastFact::unknown);
                    if *polarity {
                        fact.assume_is(ty.clone(), class_name.clone());
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
            Node::AssumeRefEq { reg_a, reg_b, polarity, .. } => {
                if !*polarity {
                    return;
                }
                let place_a = self.reg_to_place.get(reg_a).cloned();
                let place_b = self.reg_to_place.get(reg_b).cloned();
                if let (Some(pa), Some(pb)) = (place_a, place_b) {
                    let fa = self.fact_or_declared(&pa, state);
                    let fb = self.fact_or_declared(&pb, state);
                    let merged = intersect_facts(&fa, &fb);
                    state.put(pa, merged.clone());
                    state.put(pb, merged);
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
#[must_use] 
pub fn solve(cfg: &Cfg, reg_to_place: &HashMap<Reg, Place>) -> Vec<SmartCastLattice> {
    solve_with_declared(cfg, reg_to_place, None)
}

/// Like `solve`, but also seeded with a per-place declared-type map
/// that `AssumeRefEq` consults to bridge cross-variable narrowings
/// when neither side has a prior fact.
#[must_use] 
pub fn solve_with_declared(
    cfg: &Cfg,
    reg_to_place: &HashMap<Reg, Place>,
    declared_types: Option<&HashMap<Place, Type>>,
) -> Vec<SmartCastLattice> {
    solve_forward(
        cfg,
        SmartCastLattice::new(),
        SmartCastTransfer { reg_to_place, declared_types },
    )
}

/// Reproduce the per-node in-state walk inside a block. Mirrors
/// `analyses::via::states_within_block` for ad-hoc lookups.
#[must_use] 
pub fn states_within_block(
    cfg: &Cfg,
    block: crate::ir::BlockId,
    entry: SmartCastLattice,
    reg_to_place: &HashMap<Reg, Place>,
) -> Vec<SmartCastLattice> {
    states_within_block_with_declared(cfg, block, entry, reg_to_place, None)
}

#[must_use] 
pub fn states_within_block_with_declared(
    cfg: &Cfg,
    block: crate::ir::BlockId,
    entry: SmartCastLattice,
    reg_to_place: &HashMap<Reg, Place>,
    declared_types: Option<&HashMap<Place, Type>>,
) -> Vec<SmartCastLattice> {
    let mut out: Vec<SmartCastLattice> = Vec::with_capacity(cfg.block(block).nodes.len() + 1);
    let mut s = entry;
    out.push(s.clone());
    let mut t = SmartCastTransfer { reg_to_place, declared_types };
    for node in &cfg.block(block).nodes {
        t.transfer_node(node, &mut s);
        out.push(s.clone());
    }
    out
}
