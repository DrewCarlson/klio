//! Kotlin type-constraint system per spec §13.
//!
//! Implements the foundations: inference variables, per-variable bound
//! sets with the implicit `Nothing <: α <: Any?` bounds, a constraint
//! pool, and reduction + incorporation passes that drive toward a
//! fixpoint. The solver picks a substitution per inference variable
//! using the pull-up / push-down preference and the spec's GLB/LUB
//! routing.
//!
//! Designed to be consumed by the type checker at call sites for
//! type-argument inference, by branch joins for LUB, and by smart-cast
//! composition for GLB (intersection).

use std::collections::{HashMap, HashSet};

use crate::Type;

/// Fresh inference variable identity. Distinct from `Type::TypeParam`
/// (which models fixed type variables — the body of a generic
/// declaration where the parameter is unknown but immutable).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct InferenceVar(pub u32);

/// Pull-up (largest, LUB of lower bounds) or push-down (smallest, GLB of
/// upper bounds) preference attached to an inference variable. Spec
/// §13.2.2. Variables default to pull-up.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SolutionPreference {
    PullUp,
    PushDown,
}

impl Default for SolutionPreference {
    fn default() -> Self {
        Self::PullUp
    }
}

/// Per-variable bound set. The implicit `Nothing <: α <: Any?` bounds
/// are pre-installed; callers may freely add tighter bounds.
#[derive(Debug, Clone, Default)]
pub struct BoundSet {
    pub lower: Vec<Type>,
    pub upper: Vec<Type>,
    pub preference: SolutionPreference,
}

impl BoundSet {
    /// Fresh bound set seeded with the spec's implicit `Nothing <: α`
    /// and `α <: Any?` bounds.
    #[must_use]
    pub fn new() -> Self {
        Self {
            lower: vec![Type::Nothing],
            upper: vec![Type::Nullable(Box::new(Type::Any))],
            preference: SolutionPreference::PullUp,
        }
    }

    pub fn add_lower(&mut self, t: Type) -> bool {
        if self.lower.contains(&t) {
            return false;
        }
        self.lower.push(t);
        true
    }

    pub fn add_upper(&mut self, t: Type) -> bool {
        if self.upper.contains(&t) {
            return false;
        }
        self.upper.push(t);
        true
    }
}

/// `S <: T` constraint over types that may contain inference variables.
/// An inference variable is encoded as `Type::TypeParam(name)` where
/// `name` is the textual id assigned by [`ConstraintSystem::fresh`].
#[derive(Debug, Clone)]
pub struct Constraint {
    pub lhs: Type,
    pub rhs: Type,
}

/// Failure modes the reducer can hit. Surface these through diagnostics
/// T0097–T0099 at the call site.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InferenceError {
    /// Two resolved (non-inference-variable) types are unrelated and the
    /// constraint cannot be satisfied.
    UnsatisfiableConcrete { lhs: Type, rhs: Type },
    /// A nullable lhs flows into a known non-nullable rhs.
    NullableIntoNonNullable { lhs: Type, rhs: Type },
    /// A generic-class supertype required by rhs was not found on lhs.
    MissingSupertype { lhs: Type, rhs_head: String },
    /// Bounds on the same variable form a contradiction.
    ContradictoryBounds(InferenceVar),
}

/// Solver workspace: holds the set of inference variables, their bounds,
/// and the pending constraint pool.
#[derive(Debug, Default)]
pub struct ConstraintSystem {
    pub bounds: HashMap<InferenceVar, BoundSet>,
    /// Stable id-to-name lookup for the textual encoding inside
    /// `Type::TypeParam`.
    var_names: HashMap<String, InferenceVar>,
    next_id: u32,
    pending: Vec<Constraint>,
    /// Constraints already reduced. Prevents the incorporation phase
    /// from re-emitting an `S <: T` that has been processed.
    seen: HashSet<(String, String)>,
}

impl ConstraintSystem {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Allocates a fresh inference variable. The returned `Type` is the
    /// canonical textual encoding used inside constraints.
    pub fn fresh(&mut self, hint: &str) -> (InferenceVar, Type) {
        let id = InferenceVar(self.next_id);
        self.next_id += 1;
        let name = format!("?{hint}{}", id.0);
        self.var_names.insert(name.clone(), id);
        self.bounds.insert(id, BoundSet::new());
        (id, Type::TypeParam(name))
    }

    pub fn set_preference(&mut self, v: InferenceVar, p: SolutionPreference) {
        if let Some(b) = self.bounds.get_mut(&v) {
            b.preference = p;
        }
    }

    /// `true` if `t` is the canonical encoding of an inference variable.
    #[must_use]
    pub fn is_inference_var(&self, t: &Type) -> Option<InferenceVar> {
        if let Type::TypeParam(name) = t {
            self.var_names.get(name).copied()
        } else {
            None
        }
    }

    pub fn add_constraint(&mut self, lhs: Type, rhs: Type) {
        let key = (lhs.to_string(), rhs.to_string());
        if self.seen.contains(&key) {
            return;
        }
        self.pending.push(Constraint { lhs, rhs });
    }

    /// Drains the pending pool, applying spec §13.2.1 reduction rules.
    /// Returns the first inference error encountered, if any. New bounds
    /// can drive incorporation; callers loop reduce / incorporate to a
    /// fixpoint via [`Self::solve_to_fixpoint`].
    pub fn reduce(&mut self) -> Result<(), InferenceError> {
        while let Some(c) = self.pending.pop() {
            let key = (c.lhs.to_string(), c.rhs.to_string());
            if !self.seen.insert(key) {
                continue;
            }
            self.reduce_one(c.lhs, c.rhs)?;
        }
        Ok(())
    }

    fn reduce_one(&mut self, lhs: Type, rhs: Type) -> Result<(), InferenceError> {
        // Inference variable on either side -> add a bound.
        if let Some(v) = self.is_inference_var(&lhs) {
            self.bounds.get_mut(&v).unwrap().add_upper(rhs);
            return Ok(());
        }
        if let Some(v) = self.is_inference_var(&rhs) {
            self.bounds.get_mut(&v).unwrap().add_lower(lhs);
            return Ok(());
        }
        // Resolved on both sides.
        match (&lhs, &rhs) {
            // Nullable lhs into nullable rhs: peel one nullable layer.
            (Type::Nullable(a), Type::Nullable(b)) => {
                self.add_constraint((**a).clone(), (**b).clone());
                Ok(())
            }
            // Nullable lhs into a non-nullable rhs of an inference-var
            // form is handled above; an actual resolved non-nullable rhs
            // is a hard fail.
            (Type::Nullable(_), _) if !rhs.is_nullable() => {
                Err(InferenceError::NullableIntoNonNullable { lhs, rhs })
            }
            // Intersection on the right: reduce per-component.
            (_, Type::Intersection(parts)) => {
                for p in parts.clone() {
                    self.add_constraint(lhs.clone(), p);
                }
                Ok(())
            }
            // Intersection on the left: at least one component must
            // satisfy. We approximate by accepting if any does at the
            // current resolved state; otherwise schedule each as a
            // candidate constraint (last writer wins in this scaffold).
            (Type::Intersection(parts), _) => {
                if parts.iter().any(|p| p.is_subtype_of(&rhs)) {
                    Ok(())
                } else {
                    Err(InferenceError::UnsatisfiableConcrete { lhs, rhs })
                }
            }
            // Pure subtype check between resolved types.
            (a, b) => {
                if a.is_subtype_of(b) {
                    Ok(())
                } else {
                    Err(InferenceError::UnsatisfiableConcrete {
                        lhs: a.clone(),
                        rhs: b.clone(),
                    })
                }
            }
        }
    }

    /// Per spec §13.2.1: for every variable α with `S <: α` and `α <: T`,
    /// derive `S <: T`. Repeats until no fresh constraints are produced.
    pub fn incorporate(&mut self) -> Result<(), InferenceError> {
        loop {
            let mut new_constraints: Vec<(Type, Type)> = Vec::new();
            for bs in self.bounds.values() {
                for s in &bs.lower {
                    for t in &bs.upper {
                        new_constraints.push((s.clone(), t.clone()));
                    }
                }
            }
            let before = self.pending.len() + self.seen.len();
            for (s, t) in new_constraints {
                self.add_constraint(s, t);
            }
            let after_pending = self.pending.len();
            if after_pending == 0 {
                break;
            }
            self.reduce()?;
            let after = self.pending.len() + self.seen.len();
            if after == before {
                break;
            }
        }
        Ok(())
    }

    /// Loops reduce + incorporate to a fixpoint.
    pub fn solve_to_fixpoint(&mut self) -> Result<(), InferenceError> {
        loop {
            self.reduce()?;
            let before = self.seen.len();
            self.incorporate()?;
            if self.seen.len() == before && self.pending.is_empty() {
                break;
            }
        }
        Ok(())
    }

    /// Picks a concrete substitution for every inference variable using
    /// the spec §13.2.2 rule: push-down → GLB of upper bounds (= their
    /// intersection); pull-up (and default) → LUB of lower bounds.
    pub fn solve(&self) -> HashMap<InferenceVar, Type> {
        let mut out = HashMap::new();
        for (v, bs) in &self.bounds {
            let candidate = match bs.preference {
                SolutionPreference::PushDown => {
                    let uppers: Vec<Type> = bs
                        .upper
                        .iter()
                        .filter(|t| !matches!(t, Type::Nullable(inner) if matches!(**inner, Type::Any)))
                        .cloned()
                        .collect();
                    if uppers.is_empty() {
                        Type::Nullable(Box::new(Type::Any))
                    } else {
                        Type::intersect(uppers)
                    }
                }
                SolutionPreference::PullUp => {
                    let lowers: Vec<Type> =
                        bs.lower.iter().filter(|t| !matches!(t, Type::Nothing)).cloned().collect();
                    if lowers.is_empty() {
                        Type::Nothing
                    } else {
                        lub_many(&lowers)
                    }
                }
            };
            out.insert(*v, candidate);
        }
        out
    }
}

/// LUB across a slice of resolved types. Conservative implementation:
/// returns the unique element when all entries are equal; otherwise
/// promotes to a common builtin via the spec's normalization rules, and
/// falls back to `Any` / `Any?` for unrelated class types. Lifted into
/// the constraint system via [`ConstraintSystem::solve`].
#[must_use]
pub fn lub_many(types: &[Type]) -> Type {
    if types.is_empty() {
        return Type::Nothing;
    }
    let any_nullable = types.iter().any(Type::is_nullable);
    let mut iter = types.iter().map(|t| t.non_null().clone());
    let first = iter.next().unwrap();
    let mut acc = first;
    for t in iter {
        acc = lub_pair(&acc, &t);
    }
    if any_nullable {
        acc.as_nullable()
    } else {
        acc
    }
}

fn lub_pair(a: &Type, b: &Type) -> Type {
    if a == b {
        return a.clone();
    }
    if matches!(a, Type::Nothing) {
        return b.clone();
    }
    if matches!(b, Type::Nothing) {
        return a.clone();
    }
    if a.is_subtype_of(b) {
        return b.clone();
    }
    if b.is_subtype_of(a) {
        return a.clone();
    }
    Type::Any
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn implicit_bounds_seeded() {
        let bs = BoundSet::new();
        assert!(bs.lower.contains(&Type::Nothing));
        assert!(bs.upper.iter().any(|t| matches!(t, Type::Nullable(_))));
    }

    #[test]
    fn fresh_var_has_distinct_encoding() {
        let mut cs = ConstraintSystem::new();
        let (_, a) = cs.fresh("A");
        let (_, b) = cs.fresh("B");
        assert_ne!(a, b);
    }

    #[test]
    fn reduce_records_upper_bound_for_lhs_var() {
        let mut cs = ConstraintSystem::new();
        let (av, a) = cs.fresh("A");
        cs.add_constraint(a, Type::Int);
        cs.reduce().unwrap();
        assert!(cs.bounds.get(&av).unwrap().upper.contains(&Type::Int));
    }

    #[test]
    fn reduce_records_lower_bound_for_rhs_var() {
        let mut cs = ConstraintSystem::new();
        let (av, a) = cs.fresh("A");
        cs.add_constraint(Type::Int, a);
        cs.reduce().unwrap();
        assert!(cs.bounds.get(&av).unwrap().lower.contains(&Type::Int));
    }

    #[test]
    fn reduce_resolved_satisfied() {
        let mut cs = ConstraintSystem::new();
        cs.add_constraint(Type::Int, Type::Any);
        cs.reduce().unwrap();
    }

    #[test]
    fn reduce_resolved_unsatisfied() {
        let mut cs = ConstraintSystem::new();
        cs.add_constraint(Type::Int, Type::String);
        let err = cs.reduce().unwrap_err();
        assert!(matches!(err, InferenceError::UnsatisfiableConcrete { .. }));
    }

    #[test]
    fn reduce_nullable_into_nonnull_fails() {
        let mut cs = ConstraintSystem::new();
        cs.add_constraint(Type::Nullable(Box::new(Type::Int)), Type::Int);
        assert!(cs.reduce().is_err());
    }

    #[test]
    fn reduce_intersection_rhs_fans_out() {
        let mut cs = ConstraintSystem::new();
        cs.add_constraint(
            Type::Int,
            Type::Intersection(vec![Type::Int, Type::Any]),
        );
        cs.reduce().unwrap();
    }

    #[test]
    fn solve_pullup_picks_lub_of_lowers() {
        let mut cs = ConstraintSystem::new();
        let (av, a) = cs.fresh("A");
        cs.add_constraint(Type::Int, a.clone());
        cs.add_constraint(Type::Int, a);
        cs.reduce().unwrap();
        let sol = cs.solve();
        assert_eq!(sol.get(&av), Some(&Type::Int));
    }

    #[test]
    fn solve_pushdown_picks_glb_of_uppers() {
        let mut cs = ConstraintSystem::new();
        let (av, a) = cs.fresh("A");
        cs.set_preference(av, SolutionPreference::PushDown);
        cs.add_constraint(a.clone(), Type::Int);
        cs.add_constraint(a, Type::Any);
        cs.reduce().unwrap();
        let sol = cs.solve();
        assert_eq!(sol.get(&av), Some(&Type::Int));
    }

    #[test]
    fn incorporate_propagates_transitive_constraint() {
        let mut cs = ConstraintSystem::new();
        let (_, a) = cs.fresh("A");
        // Int <: a, a <: Any  => Int <: Any (already true; just check no error).
        cs.add_constraint(Type::Int, a.clone());
        cs.add_constraint(a, Type::Any);
        cs.solve_to_fixpoint().unwrap();
    }

    #[test]
    fn lub_pair_promotes_to_any() {
        assert_eq!(lub_pair(&Type::Int, &Type::String), Type::Any);
    }

    #[test]
    fn lub_lifts_nullable() {
        let r = lub_many(&[Type::Int, Type::Nullable(Box::new(Type::Int))]);
        assert_eq!(r, Type::Nullable(Box::new(Type::Int)));
    }
}
